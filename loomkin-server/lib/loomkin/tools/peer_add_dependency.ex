defmodule Loomkin.Tools.PeerAddDependency do
  @moduledoc "Agent-initiated dependency creation between tasks."

  use Jido.Action,
    name: "peer_add_dependency",
    description:
      "Create a dependency between two tasks. The task specified by task_id " <>
        "will be blocked until the depends_on task is completed (or its milestone is emitted).",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the dependent task (blocked task)"],
      depends_on_id: [
        type: :string,
        required: true,
        doc: "ID of the prerequisite task (blocking task)"
      ],
      dep_type: [
        type: :string,
        doc: "Dependency type: blocks (default), informs, or requires_output"
      ],
      milestone_name: [
        type: :string,
        doc: "Optional milestone name for milestone-based dependencies"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @valid_dep_types ~w(blocks informs requires_output)

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    depends_on_id = param!(params, :depends_on_id)
    dep_type_str = param(params, :dep_type) || "blocks"
    milestone_name = param(params, :milestone_name)

    if dep_type_str not in @valid_dep_types do
      {:error,
       "Invalid dep_type: #{dep_type_str}. Must be one of: #{Enum.join(@valid_dep_types, ", ")}"}
    else
      dep_type = String.to_existing_atom(dep_type_str)

      with {:ok, task} <- Tasks.get_task(task_id),
           {:ok, dep_task} <- Tasks.get_task(depends_on_id),
           :ok <- validate_same_team(task, dep_task, team_id) do
        opts = if milestone_name, do: [milestone_name: milestone_name], else: []

        case Tasks.add_dependency(task_id, depends_on_id, dep_type, opts) do
          {:ok, _dep} ->
            milestone_info =
              if milestone_name, do: " (milestone: #{milestone_name})", else: ""

            summary = """
            Dependency created:
              #{task.title} depends on #{dep_task.title}
              Type: #{dep_type}#{milestone_info}
            """

            {:ok, %{result: String.trim(summary)}}

          {:error, :cycle_detected} ->
            {:error, "Cannot add dependency: would create a cycle"}

          {:error, reason} ->
            {:error, "Failed to add dependency: #{inspect(reason)}"}
        end
      end
    end
  end

  defp validate_same_team(task, dep_task, team_id) do
    cond do
      task.team_id != team_id ->
        {:error, "Task #{task.id} belongs to a different team"}

      dep_task.team_id != team_id ->
        {:error, "Task #{dep_task.id} belongs to a different team"}

      true ->
        :ok
    end
  end
end
