defmodule Loomkin.Tools.PeerCompleteTask do
  @moduledoc "Agent-initiated task completion with artifact verification."

  require Logger

  use Jido.Action,
    name: "peer_complete_task",
    description:
      "Mark a task as completed with a result summary and optional structured details. " <>
        "Broadcasts task_completed so the team knows the task is done. " <>
        "You MUST provide a meaningful result AND at least one of: actions_taken, " <>
        "discoveries, or files_changed. Empty completions will be rejected.",
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
  def run(params, context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    project_path = param(context, :project_path)

    completion_attrs = %{
      result: param(params, :result) || "",
      actions_taken: param(params, :actions_taken) || [],
      discoveries: param(params, :discoveries) || [],
      files_changed: param(params, :files_changed) || [],
      decisions_made: param(params, :decisions_made) || [],
      open_questions: param(params, :open_questions) || []
    }

    # Validate that the agent actually produced something
    case validate_completion_quality(completion_attrs) do
      :ok ->
        # Verify claimed files actually exist on disk
        file_warnings = verify_files_changed(completion_attrs.files_changed, project_path)
        do_complete(team_id, task_id, completion_attrs, file_warnings)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_completion_quality(attrs) do
    result = attrs.result
    actions = attrs.actions_taken
    discoveries = attrs.discoveries
    files = attrs.files_changed

    has_result = is_binary(result) and String.length(String.trim(result)) > 20
    has_actions = is_list(actions) and actions != []
    has_discoveries = is_list(discoveries) and discoveries != []
    has_files = is_list(files) and files != []

    cond do
      not has_result ->
        {:error,
         "Task completion rejected: you must provide a meaningful result summary (>20 chars). " <>
           "Describe what you actually accomplished, with specific details."}

      not (has_actions or has_discoveries or has_files) ->
        {:error,
         "Task completion rejected: you must provide at least one of actions_taken, " <>
           "discoveries, or files_changed. If you haven't produced any artifacts, " <>
           "you haven't completed the task — keep working."}

      true ->
        :ok
    end
  end

  @doc false
  def verify_files_changed([], _project_path), do: []
  def verify_files_changed(_files, nil), do: []

  def verify_files_changed(files, project_path) when is_list(files) do
    files
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.flat_map(fn file_path ->
      full_path = Path.expand(file_path, project_path)

      if File.exists?(full_path) do
        []
      else
        Logger.warning(
          "[PeerCompleteTask] Claimed file does not exist: #{file_path} (resolved: #{full_path})"
        )

        ["#{file_path} (not found on disk)"]
      end
    end)
  end

  defp do_complete(team_id, task_id, completion_attrs, file_warnings) do
    case Tasks.get_task(task_id) do
      {:error, :not_found} ->
        {:error, "Task not found: #{task_id}"}

      {:ok, task} when task.team_id != team_id ->
        # Allow cross-team task completion when a parent team creates tasks
        # for child team agents. Log it but don't block.
        Logger.info(
          "[PeerCompleteTask] Cross-team completion: agent team=#{team_id}, task team=#{task.team_id}, task=#{task_id}"
        )

        do_complete_task(task_id, completion_attrs, file_warnings)

      {:ok, _task} ->
        do_complete_task(task_id, completion_attrs, file_warnings)
    end
  end

  defp do_complete_task(task_id, completion_attrs, file_warnings) do
    case Tasks.complete_task(task_id, completion_attrs) do
      {:ok, task} ->
        artifact_count =
          length(completion_attrs.actions_taken) +
            length(completion_attrs.discoveries) +
            length(completion_attrs.files_changed)

        warning_section =
          if file_warnings != [] do
            "\n  ⚠ File verification warnings: #{Enum.join(file_warnings, ", ")}"
          else
            ""
          end

        verified_count = length(completion_attrs.files_changed) - length(file_warnings)

        summary = """
        Task completed:
          ID: #{task.id}
          Title: #{task.title}
          Status: #{task.status}
          Artifacts: #{artifact_count} (#{length(completion_attrs.actions_taken)} actions, #{length(completion_attrs.discoveries)} discoveries, #{length(completion_attrs.files_changed)} files)
          Files verified: #{verified_count}/#{length(completion_attrs.files_changed)}#{warning_section}
        """

        {:ok, %{result: String.trim(summary), task_id: task.id}}

      {:error, reason} ->
        {:error, "Failed to complete task: #{inspect(reason)}"}
    end
  end
end
