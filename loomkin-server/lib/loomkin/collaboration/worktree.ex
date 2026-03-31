defmodule Loomkin.Collaboration.Worktree do
  @moduledoc """
  Manages git worktrees for workspace collaborators.

  Each collaborator gets an isolated git worktree so their agents operate
  on their own branch without interfering with the workspace owner's files.
  Worktrees share the object database with the main repo, so they are
  lightweight and fast to create.

  ## Branch naming

  Worktrees are created on a branch named `collab/<workspace_id>/<user_id>`
  to avoid collisions.
  """

  require Logger

  @doc """
  Create a git worktree for a collaborator.

  Runs `git worktree add <path> -b <branch>` in the workspace's project
  directory. Returns `{:ok, worktree_path}` or `{:error, reason}`.
  """
  @spec create_worktree(String.t(), integer() | String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_worktree(workspace_id, user_id, project_path) do
    wt_path = worktree_path(workspace_id, user_id, project_path)
    branch = branch_name(workspace_id, user_id)
    args = ["worktree", "add", wt_path, "-b", branch]

    case System.cmd("git", args, cd: project_path, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info(
          "[Worktree] created workspace=#{workspace_id} user=#{user_id} path=#{wt_path}"
        )

        {:ok, wt_path}

      {output, _code} ->
        cond do
          # Worktree already exists at this path — treat as success
          File.dir?(wt_path) and valid_worktree?(wt_path, project_path) ->
            Logger.info(
              "[Worktree] already exists workspace=#{workspace_id} user=#{user_id} path=#{wt_path}"
            )

            {:ok, wt_path}

          # Branch already exists — try without -b
          String.contains?(output, "already exists") ->
            create_worktree_existing_branch(workspace_id, user_id, project_path, wt_path, branch)

          true ->
            Logger.error(
              "[Worktree] creation failed workspace=#{workspace_id} user=#{user_id} output=#{output}"
            )

            {:error, {:worktree_creation_failed, output}}
        end
    end
  end

  @doc """
  Remove a collaborator's git worktree.

  Runs `git worktree remove <path>` and optionally deletes the branch.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec remove_worktree(String.t(), integer() | String.t(), String.t()) ::
          :ok | {:error, term()}
  def remove_worktree(workspace_id, user_id, project_path) do
    wt_path = worktree_path(workspace_id, user_id, project_path)

    if File.exists?(wt_path) do
      args = ["worktree", "remove", wt_path, "--force"]

      case System.cmd("git", args, cd: project_path, stderr_to_stdout: true) do
        {_output, 0} ->
          maybe_delete_branch(workspace_id, user_id, project_path)

          Logger.info(
            "[Worktree] removed workspace=#{workspace_id} user=#{user_id} path=#{wt_path}"
          )

          :ok

        {output, _code} ->
          Logger.error(
            "[Worktree] removal failed workspace=#{workspace_id} user=#{user_id} output=#{output}"
          )

          {:error, {:worktree_removal_failed, output}}
      end
    else
      :ok
    end
  end

  @doc """
  Compute the deterministic worktree path for a workspace + user pair.

  The worktree is placed adjacent to the project directory:
  `/path/to/project-collab-<workspace_short>-<user_id>/`
  """
  @spec worktree_path(String.t(), integer() | String.t(), String.t()) :: String.t()
  def worktree_path(workspace_id, user_id, project_path) do
    base_name = Path.basename(project_path)
    parent_dir = Path.dirname(project_path)
    workspace_slug = workspace_id |> to_string() |> String.replace("-", "")
    Path.join(parent_dir, "#{base_name}-collab-#{workspace_slug}-#{user_id}")
  end

  @doc """
  Compute the branch name for a collaborator's worktree.
  """
  @spec branch_name(String.t(), integer() | String.t()) :: String.t()
  def branch_name(workspace_id, user_id) do
    workspace_slug = workspace_id |> to_string() |> String.replace("-", "")
    "collab/#{workspace_slug}/#{user_id}"
  end

  # --- Private ---

  defp valid_worktree?(wt_path, project_path) do
    {output, 0} =
      System.cmd("git", ["worktree", "list", "--porcelain"],
        cd: project_path,
        stderr_to_stdout: true
      )

    String.contains?(output, wt_path)
  rescue
    _ -> false
  end

  defp create_worktree_existing_branch(workspace_id, user_id, project_path, wt_path, branch) do
    args = ["worktree", "add", wt_path, branch]

    case System.cmd("git", args, cd: project_path, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info(
          "[Worktree] created (existing branch) workspace=#{workspace_id} user=#{user_id} path=#{wt_path}"
        )

        {:ok, wt_path}

      {output, _code} ->
        Logger.error(
          "[Worktree] creation failed workspace=#{workspace_id} user=#{user_id} output=#{output}"
        )

        {:error, {:worktree_creation_failed, output}}
    end
  end

  defp maybe_delete_branch(workspace_id, user_id, project_path) do
    branch = branch_name(workspace_id, user_id)
    args = ["branch", "-D", branch]

    case System.cmd("git", args, cd: project_path, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("[Worktree] deleted branch #{branch}")

      {_output, _code} ->
        # Branch deletion is best-effort; it may already be gone
        :ok
    end
  end
end
