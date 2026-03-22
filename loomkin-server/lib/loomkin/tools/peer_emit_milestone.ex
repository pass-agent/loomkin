defmodule Loomkin.Tools.PeerEmitMilestone do
  @moduledoc "Agent-initiated milestone emission for a task."

  use Jido.Action,
    name: "peer_emit_milestone",
    description:
      "Emit a named milestone for a task. Other tasks that depend on this " <>
        "milestone will be unblocked when it is emitted.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the task emitting the milestone"],
      milestone_name: [
        type: :string,
        required: true,
        doc: "Name of the milestone to emit (e.g. 'schema_ready', 'tests_passing')"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    milestone_name = param!(params, :milestone_name)
    agent_name = param!(context, :agent_name)

    case Tasks.get_task(task_id) do
      {:error, :not_found} ->
        {:error, "Task not found: #{task_id}"}

      {:ok, task} when task.team_id != team_id ->
        {:error, "Task #{task_id} belongs to a different team"}

      {:ok, task} when task.owner != agent_name ->
        {:error, "Agent #{agent_name} does not own task #{task_id} (owner: #{task.owner})"}

      {:ok, _task} ->
        case Tasks.emit_milestone(team_id, task_id, milestone_name) do
          {:ok, task} ->
            summary = """
            Milestone emitted:
              Task: #{task.title} (#{task.id})
              Milestone: #{milestone_name}
              All milestones: #{Enum.join(task.milestones_emitted, ", ")}
            """

            {:ok, %{result: String.trim(summary), task_id: task.id}}

          {:error, reason} ->
            {:error, "Failed to emit milestone: #{inspect(reason)}"}
        end
    end
  end
end
