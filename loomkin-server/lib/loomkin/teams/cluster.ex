defmodule Loomkin.Teams.Cluster do
  @moduledoc """
  Distributed clustering support for multi-node agent swarms.

  Configures libcluster topology and provides node discovery utilities.
  Only active when `config :loomkin, :cluster, enabled: true`.

  ## Topologies

  - **Production (Fly.io)**: DNS polling via `Cluster.Strategy.DNSPoll`
  - **Development**: Gossip-based via `Cluster.Strategy.Gossip`

  ## Dependencies

  Requires `libcluster` and `horde` in mix.exs. See `docs/clustering-deps.md`.
  """

  @doc "Check whether clustering is enabled in config."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:loomkin, :cluster, [])
    |> Keyword.get(:enabled, false)
  end

  @doc """
  Return the libcluster topology configuration.

  Reads from `config :libcluster, :topologies`. Returns an empty list
  if not configured.
  """
  @spec topologies() :: keyword()
  def topologies do
    Application.get_env(:libcluster, :topologies, [])
  end

  @doc """
  Child spec for the libcluster supervisor.

  Only call this when `enabled?/0` returns true and libcluster is available.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    topologies = topologies()

    if Code.ensure_loaded?(Cluster.Supervisor) do
      %{
        id: __MODULE__,
        start: {Cluster.Supervisor, :start_link, [topologies, [name: Loomkin.ClusterSupervisor]]}
      }
    else
      # Stub when libcluster is not installed — clustering disabled
      %{
        id: __MODULE__,
        start:
          {Task, :start_link,
           [
             fn ->
               Process.sleep(:infinity)
             end
           ]}
      }
    end
  end

  @doc "List all connected nodes (including self)."
  @spec connected_nodes() :: [node()]
  def connected_nodes do
    [Node.self() | Node.list()]
  end

  @doc "Return the current node name."
  @spec local_node() :: node()
  def local_node do
    Node.self()
  end

  @doc """
  Count of agent processes per node.

  Queries the distributed registry (when clustering is on) or the local
  registry (when off) to count agent processes grouped by node.
  """
  @spec agent_count_per_node() :: %{node() => non_neg_integer()}
  def agent_count_per_node do
    if enabled?() do
      distributed_agent_counts()
    else
      %{Node.self() => local_agent_count()}
    end
  end

  @doc """
  Handle a node joining the cluster.

  Logs the event and broadcasts on PubSub for any interested listeners.
  """
  @spec handle_node_join(node()) :: :ok
  def handle_node_join(node) do
    signal = Loomkin.Signals.System.NodeJoined.new!(%{node: node})
    Loomkin.Signals.publish(signal)
    :ok
  end

  @doc """
  Handle a node leaving the cluster.

  Logs the event and broadcasts on PubSub for any interested listeners.
  """
  @spec handle_node_leave(node()) :: :ok
  def handle_node_leave(node) do
    signal = Loomkin.Signals.System.NodeLeft.new!(%{node: node})
    Loomkin.Signals.publish(signal)
    :ok
  end

  # -- Private --

  defp local_agent_count do
    Registry.select(Loomkin.Teams.AgentRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [true]}
    ])
    |> length()
  end

  defp distributed_agent_counts do
    # When Horde is available, query the distributed registry
    horde_reg = Horde.Registry

    if Code.ensure_loaded?(horde_reg) do
      apply(horde_reg, :select, [
        Loomkin.Teams.DistributedAgentRegistry,
        [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}]
      ])
      |> Enum.group_by(&node/1)
      |> Map.new(fn {n, pids} -> {n, length(pids)} end)
    else
      %{Node.self() => local_agent_count()}
    end
  end
end
