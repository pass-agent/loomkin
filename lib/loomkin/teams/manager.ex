defmodule Loomkin.Teams.Manager do
  @moduledoc "Public API for team lifecycle management."

  alias Loomkin.Decisions.{AutoLogger, Broadcaster}
  alias Loomkin.Teams.{Comms, ConflictDetector, Distributed, Rebalancer, TableRegistry}

  require Logger

  @default_max_nesting_depth 2

  @doc """
  Create a new team.

  ## Options
    * `:name` - human-readable team name (required)
    * `:project_path` - path to project (optional)

  Returns `{:ok, team_id}` where team_id is a unique ID.
  """
  def create_team(opts) do
    name = opts[:name] || raise ArgumentError, ":name is required"
    team_id = generate_team_id(name)

    # Create ETS table for team shared state (wrapped by Teams.Context for structured access)
    {:ok, ref} = TableRegistry.create_table(team_id)

    # Store team metadata
    :ets.insert(ref, {:meta, %{
      id: team_id,
      name: name,
      project_path: opts[:project_path],
      parent_team_id: nil,
      depth: 0,
      created_at: DateTime.utc_now()
    }})

    # Start decision graph nervous system processes
    start_nervous_system(team_id)

    Logger.info("[Teams] Created team #{name} (#{team_id})")
    {:ok, team_id}
  end

  @doc """
  Create a sub-team under an existing parent team.

  ## Options
    * `:name` - human-readable sub-team name (required)
    * `:project_path` - path to project (optional, inherited from parent)
    * `:max_depth` - maximum nesting depth (default: #{@default_max_nesting_depth})

  Returns `{:ok, sub_team_id}` or `{:error, reason}`.
  """
  def create_sub_team(parent_team_id, spawning_agent, opts) do
    name = opts[:name] || raise ArgumentError, ":name is required"
    max_depth = opts[:max_depth] || @default_max_nesting_depth

    case get_team_meta(parent_team_id) do
      {:ok, parent_meta} ->
        parent_depth = parent_meta[:depth] || 0

        if parent_depth + 1 > max_depth do
          {:error, :max_depth_exceeded}
        else
          sub_team_id = generate_team_id(name)
          project_path = opts[:project_path] || parent_meta[:project_path]
          {:ok, ref} = TableRegistry.create_table(sub_team_id)

          :ets.insert(ref, {:meta, %{
            id: sub_team_id,
            name: name,
            project_path: project_path,
            parent_team_id: parent_team_id,
            depth: parent_depth + 1,
            spawning_agent: spawning_agent,
            created_at: DateTime.utc_now()
          }})

          # Register sub-team relationship in parent's ETS
          parent_table = TableRegistry.get_table!(parent_team_id)
          existing = get_sub_team_ids(parent_team_id)
          :ets.insert(parent_table, {:sub_teams, [sub_team_id | existing]})

          # Start decision graph nervous system processes
          start_nervous_system(sub_team_id)

          Logger.info("[Teams] Created sub-team #{name} (#{sub_team_id}) under #{parent_team_id}")
          {:ok, sub_team_id}
        end

      :error ->
        {:error, :parent_not_found}
    end
  end

  @doc "List sub-team IDs for a given parent team."
  @spec list_sub_teams(String.t()) :: [String.t()]
  def list_sub_teams(parent_team_id) do
    get_sub_team_ids(parent_team_id)
  end

  @doc "Get the parent team ID for a given team, or nil if it's a root team."
  @spec get_parent_team(String.t()) :: {:ok, String.t()} | :none
  def get_parent_team(team_id) do
    case get_team_meta(team_id) do
      {:ok, %{parent_team_id: parent_id}} when is_binary(parent_id) -> {:ok, parent_id}
      _ -> :none
    end
  end

  @doc """
  Spawn an agent in a team.

  Starts a Teams.Agent GenServer under the AgentSupervisor.
  """
  def spawn_agent(team_id, name, role, opts \\ []) do
    child_opts = [
      team_id: team_id,
      name: name,
      role: role,
      project_path: opts[:project_path] || get_team_project_path(team_id),
      model: opts[:model]
    ]

    child_opts =
      if opts[:permission_mode],
        do: Keyword.put(child_opts, :permission_mode, opts[:permission_mode]),
        else: child_opts

    Distributed.start_child({Loomkin.Teams.Agent, child_opts})
  end

  @doc """
  Spawn a context keeper in a team.

  Options:
    * `:topic` - topic label for the keeper
    * `:source_agent` - name of the agent that offloaded context
    * `:messages` - list of message maps to store
    * `:metadata` - optional metadata map
  """
  def spawn_keeper(team_id, opts) do
    keeper_id = Ecto.UUID.generate()

    child_opts = [
      id: keeper_id,
      team_id: team_id,
      topic: opts[:topic] || "unnamed",
      source_agent: opts[:source_agent] || "unknown",
      messages: opts[:messages] || [],
      metadata: opts[:metadata] || %{}
    ]

    Distributed.start_child({Loomkin.Teams.ContextKeeper, child_opts})
  end

  @doc "List all context keepers in a team."
  def list_keepers(team_id) do
    Loomkin.Teams.ContextRetrieval.list_keepers(team_id)
  end

  @doc """
  Update the project path for a team and all its running agents.

  Also recursively updates any sub-teams so the entire team tree uses the
  new directory.
  """
  @spec update_project_path(String.t(), String.t()) :: :ok | {:error, :not_found}
  def update_project_path(team_id, new_path) do
    case TableRegistry.get_table(team_id) do
      {:ok, table} ->
        # Update team ETS metadata
        case :ets.lookup(table, :meta) do
          [{:meta, meta}] ->
            :ets.insert(table, {:meta, %{meta | project_path: new_path}})

          _ ->
            :ok
        end

        # Notify all running agents in this team
        for %{pid: pid} <- list_agents(team_id) do
          GenServer.cast(pid, {:update_project_path, new_path})
        end

        # Recursively update sub-teams
        for sub_id <- list_sub_teams(team_id) do
          update_project_path(sub_id, new_path)
        end

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "Stop an agent gracefully."
  def stop_agent(team_id, name) do
    case find_agent(team_id, name) do
      {:ok, pid} ->
        Distributed.terminate_child(pid)

      :error ->
        :ok
    end
  end

  @doc "List all agents in a team."
  def list_agents(team_id) do
    Registry.select(Loomkin.Teams.AgentRegistry, [
      {{{team_id, :"$1"}, :"$2", :"$3"}, [], [%{name: :"$1", pid: :"$2", meta: :"$3"}]}
    ])
    |> Enum.map(fn %{name: name, pid: pid, meta: meta} ->
      %{name: name, pid: pid, role: meta[:role] || meta.role, status: meta[:status] || meta.status}
    end)
  end

  @doc "Find an agent by team and name."
  def find_agent(team_id, name) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, name}) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Dissolve a team — cascade to sub-teams, stop all agents, clean up ETS, broadcast dissolution."
  def dissolve_team(team_id) do
    # Cascade: dissolve all sub-teams first (depth-first)
    for sub_id <- list_sub_teams(team_id) do
      dissolve_team(sub_id)
    end

    # Notify parent team's spawning agent if this is a sub-team
    notify_parent_on_dissolution(team_id)

    # Stop all agents
    agents = list_agents(team_id)
    Enum.each(agents, fn agent -> stop_agent(team_id, agent.name) end)

    # Stop all context keepers
    keepers = list_keepers(team_id)
    Enum.each(keepers, fn keeper ->
      if Process.alive?(keeper.pid), do: Distributed.terminate_child(keeper.pid)
    end)

    # Stop decision graph nervous system processes
    stop_nervous_system(team_id)

    # Reset rate limiter budget
    Loomkin.Teams.RateLimiter.reset_team(team_id)

    # Reset cost tracker
    Loomkin.Teams.CostTracker.reset_team(team_id)

    # Remove from parent's sub_teams list
    remove_from_parent(team_id)

    # Delete ETS table
    TableRegistry.delete_table(team_id)

    # Broadcast dissolution
    Phoenix.PubSub.broadcast(Loomkin.PubSub, "team:#{team_id}", {:team_dissolved, team_id})

    Logger.info("[Teams] Dissolved team #{team_id}")
    :ok
  end

  # Private helpers

  defp generate_team_id(name) do
    sanitized = name |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.slice(0, 20)
    suffix = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{sanitized}-#{suffix}"
  end

  defp get_team_project_path(team_id) do
    case get_team_meta(team_id) do
      {:ok, meta} -> meta[:project_path]
      :error -> nil
    end
  end

  defp get_team_meta(team_id) do
    case TableRegistry.get_table(team_id) do
      {:ok, table} ->
        case :ets.lookup(table, :meta) do
          [{:meta, meta}] -> {:ok, meta}
          _ -> :error
        end

      {:error, :not_found} ->
        :error
    end
  end

  defp get_sub_team_ids(parent_team_id) do
    case TableRegistry.get_table(parent_team_id) do
      {:ok, table} ->
        case :ets.lookup(table, :sub_teams) do
          [{:sub_teams, ids}] -> ids
          [] -> []
        end

      {:error, :not_found} ->
        []
    end
  end

  defp remove_from_parent(team_id) do
    case get_team_meta(team_id) do
      {:ok, %{parent_team_id: parent_id}} when is_binary(parent_id) ->
        case TableRegistry.get_table(parent_id) do
          {:ok, table} ->
            updated = get_sub_team_ids(parent_id) -- [team_id]
            :ets.insert(table, {:sub_teams, updated})

          {:error, :not_found} ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp start_nervous_system(team_id) do
    if Application.get_env(:loomkin, :start_nervous_system, true) do
      try do
        Distributed.start_child({AutoLogger, team_id: team_id})
        Distributed.start_child({Broadcaster, team_id: team_id})
        Distributed.start_child({Rebalancer, team_id: team_id})
        Distributed.start_child({ConflictDetector, team_id: team_id})
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_nervous_system(team_id) do
    for key <- [{:auto_logger, team_id}, {:broadcaster, team_id}, {:rebalancer, team_id}, {:conflict_detector, team_id}] do
      case Registry.lookup(Loomkin.Teams.AgentRegistry, key) do
        [{pid, _}] -> Distributed.terminate_child(pid)
        [] -> :ok
      end
    end
  end

  defp notify_parent_on_dissolution(team_id) do
    case get_team_meta(team_id) do
      {:ok, %{parent_team_id: parent_id, spawning_agent: agent}} when is_binary(parent_id) and not is_nil(agent) ->
        Comms.send_to(parent_id, agent, {:sub_team_completed, team_id})

      _ ->
        :ok
    end
  end
end
