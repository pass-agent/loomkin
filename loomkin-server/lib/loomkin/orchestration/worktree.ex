defmodule Loomkin.Orchestration.Worktree do
  @moduledoc """
  Owns a single git worktree for the lifetime of an epic.

  On `init/1` we add a worktree at `path` from `base_branch` of `repo_path`
  on a new branch. On `terminate/2` we remove it (force) so leaked
  worktrees don't pollute the repo even when the orchestrator crashes.

  The runtime can run with `dry_run: true` for tests — no actual git commands
  are issued; the GenServer just remembers the requested path and branch.
  """
  use GenServer

  require Logger

  defstruct [:repo_path, :path, :branch, :base_branch, :dry_run, :created?]

  @type t :: %__MODULE__{
          repo_path: Path.t(),
          path: Path.t(),
          branch: String.t(),
          base_branch: String.t(),
          dry_run: boolean(),
          created?: boolean()
        }

  ## Public API

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Returns the resolved %Worktree{} state."
  def info(server), do: GenServer.call(server, :info)

  @doc "Runs a function with the worktree path as its argument."
  def with_path(server, fun) when is_function(fun, 1) do
    %{path: path} = info(server)
    fun.(path)
  end

  @doc """
  Build start options for a worktree rooted at the given workspace's project_path.

  Returns the keyword list ready for `start_link/1`. The worktree is created
  off the workspace's current `project_path` on a fresh branch named after the
  epic. Pass `:dry_run` to avoid touching git (useful in tests).
  """
  @spec attach_to_workspace_opts(binary(), String.t(), keyword()) :: keyword()
  def attach_to_workspace_opts(workspace_id, epic_id, opts \\ []) when is_binary(epic_id) do
    project_path =
      case Loomkin.Workspace.Server.get_team_id(workspace_id) do
        _team_id ->
          # The Workspace.Server doesn't expose project_path directly via a
          # getter, but `find_or_start` stores it in state. For now we ask the
          # caller to pass it explicitly via opts to avoid coupling here.
          Keyword.get(opts, :project_path) || raise(ArgumentError, "project_path required")
      end

    branch = "orchestration/epic-#{epic_id}"
    base_branch = Keyword.get(opts, :base_branch, "main")
    worktree_root = Keyword.get(opts, :worktree_root, default_worktree_root())
    path = Path.join(worktree_root, "epic-#{epic_id}")

    [
      repo_path: project_path,
      path: path,
      branch: branch,
      base_branch: base_branch,
      dry_run: Keyword.get(opts, :dry_run, false)
    ]
  end

  defp default_worktree_root do
    System.get_env("LOOMKIN_WORKTREE_ROOT") ||
      Path.join(System.tmp_dir!(), "loomkin-orchestration-worktrees")
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      repo_path: Keyword.fetch!(opts, :repo_path),
      path: Keyword.fetch!(opts, :path),
      branch: Keyword.fetch!(opts, :branch),
      base_branch: Keyword.get(opts, :base_branch, "main"),
      dry_run: Keyword.get(opts, :dry_run, false),
      created?: false
    }

    case create_worktree(state) do
      :ok -> {:ok, %{state | created?: true}}
      {:error, reason} -> {:stop, {:worktree_create_failed, reason}}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state, state}

  @impl true
  def terminate(_reason, %{created?: true} = state) do
    remove_worktree(state)
  end

  def terminate(_reason, _state), do: :ok

  ## git operations

  defp create_worktree(%{dry_run: true}), do: :ok

  defp create_worktree(%{repo_path: repo, path: path, branch: branch, base_branch: base}) do
    File.mkdir_p!(Path.dirname(path))

    case System.cmd("git", ["-C", repo, "worktree", "add", "-b", branch, path, base],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.error("git worktree add failed (#{code}): #{out}")
        {:error, {code, out}}
    end
  end

  defp remove_worktree(%{dry_run: true}), do: :ok

  defp remove_worktree(%{repo_path: repo, path: path}) do
    case System.cmd("git", ["-C", repo, "worktree", "remove", "--force", path],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        Logger.warning("git worktree remove failed: #{out}")
        File.rm_rf!(path)
        :ok
    end
  end
end
