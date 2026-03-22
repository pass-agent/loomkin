defmodule Loomkin.Tools.PeerStartSpeculative do
  @moduledoc "Agent-initiated speculative execution on a blocked task."

  use Jido.Action,
    name: "peer_start_speculative",
    description:
      "Start speculative execution on a task that is blocked, using an assumed output " <>
        "from the blocker. The task will proceed tentatively based on the assumption.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [
        type: :string,
        required: true,
        doc: "ID of the blocked task to start speculatively"
      ],
      blocker_task_id: [
        type: :string,
        required: true,
        doc: "ID of the blocker task whose output is assumed"
      ],
      assumed_output: [type: :string, required: true, doc: "Assumed output of the blocker task"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    blocker_task_id = param!(params, :blocker_task_id)
    assumed_output = param!(params, :assumed_output)

    with {:task, {:ok, task}} <- {:task, Tasks.get_task(task_id)},
         :ok <- validate_team(task, team_id, task_id),
         {:blocker, {:ok, _blocker}} <- {:blocker, Tasks.get_task(blocker_task_id)} do
      case Tasks.start_speculative(task_id, blocker_task_id, assumed_output) do
        {:ok, started_task} ->
          summary = """
          Speculative execution started:
            Task: #{started_task.id} (#{started_task.title})
            Based on blocker: #{blocker_task_id}
            Assumed output: #{String.slice(assumed_output, 0, 100)}
          """

          {:ok, %{result: String.trim(summary), task_id: started_task.id}}

        {:error, :invalid_transition} ->
          {:error, "Task must be pending or blocked to start speculative execution"}

        {:error, reason} ->
          {:error, "Failed to start speculative execution: #{inspect(reason)}"}
      end
    else
      {:task, {:error, :not_found}} ->
        {:error, "Task not found: #{task_id}"}

      {:blocker, {:error, :not_found}} ->
        {:error, "Blocker task not found: #{blocker_task_id}"}

      {:error, _} = err ->
        err
    end
  end

  defp validate_team(task, team_id, task_id) do
    if task.team_id == team_id,
      do: :ok,
      else: {:error, "Task #{task_id} belongs to a different team"}
  end
end
