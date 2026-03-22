defmodule Loomkin.Teams.Migration do
  @moduledoc """
  Agent migration between nodes in a distributed cluster.

  Serializes agent state on the source node, stops the agent, and restarts
  it on the target node. This enables load balancing and fault recovery
  across a multi-node swarm.

  ## Dependencies

  Requires clustering to be enabled and Horde available.
  See `docs/clustering-deps.md`.
  """

  alias Loomkin.Teams.Cluster
  alias Loomkin.Teams.Distributed
  alias Loomkin.Teams.Manager

  @doc """
  Migrate an agent from the current node to a target node.

  1. Serializes the agent's state via `Agent.get_state/1`
  2. Stops the agent on the current node
  3. Starts a new agent on the target node with the serialized state

  Returns `{:ok, new_pid}` on success, or `{:error, reason}` on failure.
  """
  @spec migrate_agent(String.t(), String.t(), node()) ::
          {:ok, pid()} | {:error, term()}
  def migrate_agent(team_id, agent_name, target_node) do
    unless Cluster.enabled?() do
      {:error, :clustering_disabled}
    else
      do_migrate(team_id, agent_name, target_node)
    end
  end

  @doc """
  Serialize an agent's state into a transferable map.

  Calls `Loomkin.Teams.Agent.get_state/1` to retrieve the GenServer state,
  then extracts the fields needed to reconstruct the agent on another node.
  """
  @spec serialize_agent_state(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def serialize_agent_state(team_id, agent_name) do
    case Manager.find_agent(team_id, agent_name) do
      {:ok, pid} ->
        try do
          state = Loomkin.Teams.Agent.get_state(pid)

          serialized = %{
            team_id: team_id,
            name: agent_name,
            role: state[:role] || state.role,
            model: state[:model] || state[:assigned_model],
            project_path: state[:project_path],
            metadata: Map.get(state, :metadata, %{})
          }

          {:ok, serialized}
        catch
          :exit, reason -> {:error, {:agent_unreachable, reason}}
        end

      :error ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Deserialize agent state and start the agent with it.

  Takes a serialized state map (from `serialize_agent_state/2`) and starts
  a new agent process with those parameters.
  """
  @spec deserialize_and_start(map()) :: {:ok, pid()} | {:error, term()}
  def deserialize_and_start(%{} = state) do
    Manager.spawn_agent(
      state.team_id,
      state.name,
      state.role,
      model: state[:model],
      project_path: state[:project_path]
    )
  end

  # -- Private --

  defp do_migrate(team_id, agent_name, target_node) do
    with {:ok, state} <- serialize_agent_state(team_id, agent_name),
         :ok <- stop_agent_on_source(team_id, agent_name) do
      start_agent_on_target(state, target_node)
    end
  end

  defp stop_agent_on_source(team_id, agent_name) do
    case Manager.find_agent(team_id, agent_name) do
      {:ok, pid} ->
        Distributed.terminate_child(pid)

      :error ->
        # Agent already gone, that's fine
        :ok
    end
  end

  defp start_agent_on_target(state, target_node) do
    if target_node == Node.self() do
      deserialize_and_start(state)
    else
      :rpc.call(target_node, __MODULE__, :deserialize_and_start, [state])
      |> case do
        {:ok, pid} -> {:ok, pid}
        {:error, _} = err -> err
        {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
      end
    end
  end
end
