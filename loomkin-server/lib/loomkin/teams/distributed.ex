defmodule Loomkin.Teams.Distributed do
  @moduledoc """
  Wrapper around Horde.DynamicSupervisor and Horde.Registry for distributed
  agent management.

  When clustering is enabled (`config :loomkin, :cluster, enabled: true`), agents
  are started under a Horde-backed DynamicSupervisor and registered in a
  Horde-backed Registry. This allows agents to be discovered and migrated
  across nodes.

  When clustering is disabled, falls back to local DynamicSupervisor and
  Registry — no behavioral change from the non-clustered path.

  ## Dependencies

  Requires `horde ~> 0.9` in mix.exs. See `docs/clustering-deps.md`.
  """

  alias Loomkin.Teams.Cluster

  @distributed_supervisor Loomkin.Teams.DistributedAgentSupervisor
  @distributed_registry Loomkin.Teams.DistributedAgentRegistry

  @local_supervisor Loomkin.Teams.AgentSupervisor
  @local_registry Loomkin.Teams.AgentRegistry

  # Runtime-resolved Horde modules to avoid compile-time warnings when
  # Horde is not installed. All Horde calls go through apply/3.
  @horde_dsup Horde.DynamicSupervisor
  @horde_reg Horde.Registry

  @doc """
  Start the distributed supervisor (Horde-backed).

  Returns a child spec suitable for inclusion in a supervision tree.
  Only call when clustering is enabled and Horde is available.
  """
  @spec start_distributed_supervisor(atom(), keyword()) :: Supervisor.child_spec()
  def start_distributed_supervisor(name \\ @distributed_supervisor, opts \\ []) do
    members = opts[:members] || :auto

    %{
      id: name,
      start:
        {@horde_dsup, :start_link,
         [
           [
             name: name,
             strategy: :one_for_one,
             members: members,
             distribution_strategy: Horde.UniformQuorumDistribution
           ]
         ]}
    }
  end

  @doc """
  Start the distributed registry (Horde-backed).

  Returns a child spec suitable for inclusion in a supervision tree.
  Only call when clustering is enabled and Horde is available.
  """
  @spec start_distributed_registry(atom(), keyword()) :: Supervisor.child_spec()
  def start_distributed_registry(name \\ @distributed_registry, opts \\ []) do
    members = opts[:members] || :auto

    %{
      id: name,
      start:
        {@horde_reg, :start_link,
         [
           [
             name: name,
             keys: :unique,
             members: members
           ]
         ]}
    }
  end

  @doc """
  Return child specs for distributed supervision.

  When clustering is enabled and Horde is available, returns specs for
  Horde DynamicSupervisor + Horde Registry. Otherwise returns an empty list
  (local supervisor/registry are already started by `Loomkin.Teams.Supervisor`).
  """
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    if Cluster.enabled?() and horde_available?() do
      [
        start_distributed_registry(),
        start_distributed_supervisor()
      ]
    else
      []
    end
  end

  @doc """
  Start a child process under the appropriate supervisor.

  Routes to Horde or local DynamicSupervisor based on cluster config.
  """
  @spec start_child(Supervisor.child_spec() | {module(), keyword()}) ::
          DynamicSupervisor.on_start_child()
  def start_child(child_spec) do
    if Cluster.enabled?() and horde_available?() do
      apply(@horde_dsup, :start_child, [@distributed_supervisor, child_spec])
    else
      DynamicSupervisor.start_child(@local_supervisor, child_spec)
    end
  end

  @doc """
  Terminate a child process on the appropriate supervisor.
  """
  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) do
    if Cluster.enabled?() and horde_available?() do
      apply(@horde_dsup, :terminate_child, [@distributed_supervisor, pid])
    else
      DynamicSupervisor.terminate_child(@local_supervisor, pid)
    end
  end

  @doc """
  Look up a process in the appropriate registry.

  Returns `[{pid, value}]` or `[]`.
  """
  @spec lookup(term()) :: [{pid(), term()}]
  def lookup(key) do
    if Cluster.enabled?() and horde_available?() do
      apply(@horde_reg, :lookup, [@distributed_registry, key])
    else
      Registry.lookup(@local_registry, key)
    end
  end

  @doc """
  Register the current process in the appropriate registry.
  """
  @spec register(term(), term()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(key, value) do
    if Cluster.enabled?() and horde_available?() do
      apply(@horde_reg, :register, [@distributed_registry, key, value])
    else
      Registry.register(@local_registry, key, value)
    end
  end

  @doc "Return the name of the active supervisor module."
  @spec active_supervisor() :: atom()
  def active_supervisor do
    if Cluster.enabled?() and horde_available?() do
      @distributed_supervisor
    else
      @local_supervisor
    end
  end

  @doc "Return the name of the active registry module."
  @spec active_registry() :: atom()
  def active_registry do
    if Cluster.enabled?() and horde_available?() do
      @distributed_registry
    else
      @local_registry
    end
  end

  @doc "Check if Horde is loaded and available."
  @spec horde_available?() :: boolean()
  def horde_available? do
    Code.ensure_loaded?(@horde_dsup) and Code.ensure_loaded?(@horde_reg)
  end
end
