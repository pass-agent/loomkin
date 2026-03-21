defmodule Loomkin.Teams.Manager do
  @moduledoc "Public API for team lifecycle management."

  require Logger

  alias Loomkin.Decisions.AutoLogger
  alias Loomkin.Decisions.Broadcaster
  alias Loomkin.Signals.Team.ChildTeamCreated
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.ComplexityMonitor
  alias Loomkin.Teams.ConflictDetector
  alias Loomkin.Teams.Distributed
  alias Loomkin.Teams.MessageScheduler
  alias Loomkin.Teams.Negotiation
  alias Loomkin.Teams.Rebalancer
  alias Loomkin.Teams.Rendezvous
  alias Loomkin.Teams.TableRegistry

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
    :ets.insert(
      ref,
      {:meta,
       %{
         id: team_id,
         name: name,
         project_path: opts[:project_path],
         parent_team_id: nil,
         depth: 0,
         created_at: DateTime.utc_now()
       }}
    )

    # Start decision graph nervous system processes
    start_nervous_system(team_id)

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
    max_depth = opts[:max_depth] || config_max_nesting_depth()

    # Use ensure_team_table to recover the parent's ETS table if it was lost
    # (e.g. after an app restart when TableRegistry state is cleared).
    case ensure_team_table(parent_team_id) do
      {:ok, parent_meta} ->
        parent_depth = parent_meta[:depth] || 0

        if parent_depth + 1 > max_depth do
          {:error, :max_depth_exceeded}
        else
          sub_team_id = generate_team_id(name)
          project_path = opts[:project_path] || parent_meta[:project_path]
          {:ok, ref} = TableRegistry.create_table(sub_team_id)

          :ets.insert(
            ref,
            {:meta,
             %{
               id: sub_team_id,
               name: name,
               project_path: project_path,
               parent_team_id: parent_team_id,
               depth: parent_depth + 1,
               spawning_agent: spawning_agent,
               created_at: DateTime.utc_now()
             }}
          )

          # Register sub-team relationship in parent's ETS
          parent_table = TableRegistry.get_table!(parent_team_id)
          existing = get_sub_team_ids(parent_team_id)
          :ets.insert(parent_table, {:sub_teams, [sub_team_id | existing]})

          # Start decision graph nervous system processes
          start_nervous_system(sub_team_id)

          # Publish ChildTeamCreated so LiveView can render tree nodes from signal data
          signal =
            ChildTeamCreated.new!(%{
              team_id: sub_team_id,
              parent_team_id: parent_team_id,
              team_name: name,
              depth: parent_depth + 1
            })

          Loomkin.Signals.publish(signal)

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

  @doc "Get the parent team ID for a given team, or :error if it's a root team or not found."
  @spec get_parent_team(String.t()) :: {:ok, String.t()} | :error
  def get_parent_team(team_id) do
    case get_team_meta(team_id) do
      {:ok, %{parent_team_id: parent_id}} when is_binary(parent_id) -> {:ok, parent_id}
      _ -> :error
    end
  end

  @doc "Get sibling team IDs (other sub-teams under the same parent)."
  @spec get_sibling_teams(String.t()) :: {:ok, [String.t()]} | :error
  def get_sibling_teams(team_id) do
    case get_parent_team(team_id) do
      {:ok, parent_id} ->
        siblings = get_sub_team_ids(parent_id) -- [team_id]
        {:ok, siblings}

      :error ->
        :error
    end
  end

  @doc "Get child (sub-team) IDs for a given team."
  @spec get_child_teams(String.t()) :: [String.t()]
  def get_child_teams(team_id) do
    get_sub_team_ids(team_id)
  end

  @doc "Get team name from metadata."
  @spec get_team_name(String.t()) :: String.t() | nil
  def get_team_name(team_id) do
    case get_team_meta(team_id) do
      {:ok, meta} -> meta[:name]
      :error -> nil
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
      if opts[:role_config],
        do: Keyword.put(child_opts, :role_config, opts[:role_config]),
        else: child_opts

    child_opts =
      if opts[:permission_mode],
        do: Keyword.put(child_opts, :permission_mode, opts[:permission_mode]),
        else: child_opts

    child_opts =
      if opts[:kin_agents],
        do: Keyword.put(child_opts, :kin_agents, opts[:kin_agents]),
        else: child_opts

    child_opts =
      if opts[:session_id],
        do: Keyword.put(child_opts, :session_id, opts[:session_id]),
        else: child_opts

    result = Distributed.start_child({Loomkin.Teams.Agent, child_opts})

    case result do
      {:ok, pid} ->
        Logger.info("[Kin:spawn] agent=#{name} role=#{role} team=#{team_id} pid=#{inspect(pid)}")
        Loomkin.Teams.AgentWatcher.watch(Loomkin.Teams.AgentWatcher, pid, team_id, name)

      {:error, reason} ->
        Logger.error(
          "[Kin:spawn] FAILED agent=#{name} role=#{role} team=#{team_id} reason=#{inspect(reason)}"
        )
    end

    result
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
        for %{pid: pid} <- list_agents(team_id), Process.alive?(pid) do
          Loomkin.Teams.Agent.update_project_path(pid, new_path)
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

  @doc "Update the model on all agents in a team and its sub-teams."
  @spec update_all_models(String.t(), String.t()) :: :ok
  def update_all_models(team_id, new_model) do
    for %{pid: pid} <- list_agents(team_id) do
      Loomkin.Teams.Agent.update_model(pid, new_model)
    end

    for sub_id <- list_sub_teams(team_id) do
      update_all_models(sub_id, new_model)
    end

    :ok
  end

  @doc "Cancel active agent loops across a team and its sub-teams."
  @spec cancel_all_loops(String.t()) :: :ok
  def cancel_all_loops(team_id) do
    for %{pid: pid} <- list_agents(team_id) do
      try do
        GenServer.call(pid, :cancel, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    for sub_id <- list_sub_teams(team_id) do
      cancel_all_loops(sub_id)
    end

    :ok
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
    raw =
      Registry.select(Loomkin.Teams.AgentRegistry, [
        {{{team_id, :"$1"}, :"$2", :"$3"}, [], [%{name: :"$1", pid: :"$2", meta: :"$3"}]}
      ])

    filtered =
      Enum.filter(raw, fn %{pid: pid, meta: meta} ->
        Process.alive?(pid) and is_map(meta) and
          (Map.has_key?(meta, :role) or Map.has_key?(meta, "role"))
      end)

    dropped = length(raw) - length(filtered)

    if dropped > 0 do
      dropped_names = Enum.map(raw -- filtered, & &1.name)

      Logger.warning(
        "[Kin:roster] team=#{team_id} dropped #{dropped} entries: #{inspect(dropped_names)} (no :role in metadata)"
      )
    end

    agents =
      Enum.map(filtered, fn %{name: name, pid: pid, meta: meta} ->
        %{
          name: name,
          pid: pid,
          role: meta[:role] || meta["role"],
          status: meta[:status] || meta["status"] || :idle,
          model: meta[:model] || meta["model"]
        }
      end)

    Logger.debug(
      "[Kin:roster] team=#{team_id} found #{length(agents)} agents: #{inspect(Enum.map(agents, & &1.name))}"
    )

    agents
  end

  @doc "List all agents in a team and its sub-teams recursively."
  @spec list_all_agents(String.t()) :: [map()]
  def list_all_agents(team_id) do
    own = list_agents(team_id)

    sub =
      for sub_id <- list_sub_teams(team_id),
          agent <- list_all_agents(sub_id),
          do: agent

    own ++ sub
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
    signal = Loomkin.Signals.Team.Dissolved.new!(%{team_id: team_id})
    Loomkin.Signals.publish(signal)

    :ok
  end

  # Private helpers

  defp generate_team_id(name) do
    sanitized =
      name |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.slice(0, 20)

    suffix = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{sanitized}-#{suffix}"
  end

  @doc "Get the project path for a team from ETS metadata."
  @spec get_team_project_path(String.t()) :: String.t() | nil
  def get_team_project_path(team_id) do
    case get_team_meta(team_id) do
      {:ok, meta} -> meta[:project_path]
      :error -> nil
    end
  end

  @doc "Get team metadata from ETS. Returns {:ok, meta} or :error."
  @spec get_team_meta(String.t()) :: {:ok, map()} | :error
  def get_team_meta(team_id) do
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

  @doc """
  Ensure the ETS table for a team exists, recovering from the workspace DB if needed.

  After an app restart, ETS tables are lost but the workspace DB still knows
  the team_id. This function checks if the table exists and recreates it
  from workspace data if missing.

  Returns `{:ok, meta}` if the table exists or was recovered, `:error` otherwise.
  """
  @spec ensure_team_table(String.t()) :: {:ok, map()} | :error
  def ensure_team_table(team_id) do
    case get_team_meta(team_id) do
      {:ok, meta} ->
        {:ok, meta}

      :error ->
        recover_team_table(team_id)
    end
  end

  defp recover_team_table(team_id) do
    alias Loomkin.Repo
    alias Loomkin.Workspace

    import Ecto.Query, only: [from: 2]

    workspace =
      try do
        Repo.one(from w in Workspace, where: w.team_id == ^team_id, limit: 1)
      rescue
        _error ->
          Logger.warning("[Manager] DB unavailable while recovering ETS for team=#{team_id}")

          nil
      catch
        :exit, _reason ->
          Logger.warning("[Manager] DB unavailable while recovering ETS for team=#{team_id}")

          nil
      end

    case workspace do
      nil ->
        Logger.warning("[Manager] Cannot recover ETS for team=#{team_id}: no workspace found")
        :error

      workspace ->
        Logger.info(
          "[Manager] Recovering ETS table for team=#{team_id} from workspace=#{workspace.id}"
        )

        project_path =
          case workspace.project_paths do
            [p | _] -> p
            _ -> nil
          end

        {:ok, ref} = TableRegistry.create_table(team_id)

        meta = %{
          id: team_id,
          name: workspace.name,
          project_path: project_path,
          parent_team_id: nil,
          depth: 0,
          created_at: DateTime.utc_now()
        }

        :ets.insert(ref, {:meta, meta})

        # Re-start nervous system processes and rehydrate keepers for the recovered team
        ensure_nervous_system(team_id)

        {:ok, meta}
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

  @doc """
  Ensure nervous system processes and context keepers are running for a team.

  Idempotent — if processes are already running (registered in AgentRegistry),
  they won't be started again. Used by WorkspaceServer to recover team state
  after app restart when the ETS table is recreated.

  Also rehydrates context keepers from the database so offloaded context
  survives WorkspaceServer crashes and app restarts.
  """
  def ensure_nervous_system(team_id) do
    start_nervous_system(team_id)
    Loomkin.Teams.ContextKeeper.rehydrate_from_db(team_id)
  end

  defp start_nervous_system(team_id) do
    if Application.get_env(:loomkin, :start_nervous_system, true) do
      components = [
        {AutoLogger, team_id: team_id},
        {Broadcaster, team_id: team_id},
        {Rebalancer, team_id: team_id},
        {ConflictDetector, team_id: team_id},
        {MessageScheduler, team_id: team_id},
        {Negotiation, team_id: team_id},
        {Rendezvous, team_id: team_id},
        {ComplexityMonitor, team_id: team_id}
      ]

      for {mod, opts} <- components do
        try do
          Distributed.start_child({mod, opts})
        catch
          :exit, reason ->
            Logger.warning(
              "[Kin:team] Failed to start #{inspect(mod)} for team #{team_id}: #{inspect(reason)}"
            )
        end
      end
    end
  end

  defp stop_nervous_system(team_id) do
    for key <- [
          {:auto_logger, team_id},
          {:broadcaster, team_id},
          {:rebalancer, team_id},
          {:conflict_detector, team_id},
          {:message_scheduler, team_id},
          {:negotiation, team_id},
          {:rendezvous, team_id},
          {:complexity_monitor, team_id}
        ] do
      case Registry.lookup(Loomkin.Teams.AgentRegistry, key) do
        [{pid, _}] -> Distributed.terminate_child(pid)
        [] -> :ok
      end
    end
  end

  defp notify_parent_on_dissolution(team_id) do
    case get_team_meta(team_id) do
      {:ok, %{parent_team_id: parent_id, spawning_agent: agent}}
      when is_binary(parent_id) and not is_nil(agent) ->
        Comms.send_to(parent_id, agent, {:sub_team_completed, team_id})

      _ ->
        :ok
    end
  end

  defp config_max_nesting_depth do
    Loomkin.Config.get(:teams, :max_nesting_depth) || @default_max_nesting_depth
  end
end
