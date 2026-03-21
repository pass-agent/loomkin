defmodule Loomkin.Teams.Supervisor do
  @moduledoc """
  Supervises team agent processes.

  Starts a Registry for named agents, a DynamicSupervisor for managing
  agent lifecycles, a RateLimiter, and a Task.Supervisor for async work.

  When clustering is enabled (`config :loomkin, :cluster, enabled: true`),
  also starts Horde-backed distributed supervisor and registry via
  `Loomkin.Teams.Distributed`, plus the libcluster supervisor via
  `Loomkin.Teams.Cluster`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        Loomkin.Teams.TableRegistry,
        {Registry, keys: :unique, name: Loomkin.Teams.AgentRegistry},
        {Registry, keys: :unique, name: Loomkin.Keepers.Registry},
        {DynamicSupervisor, name: Loomkin.Teams.AgentSupervisor, strategy: :one_for_one},
        {Loomkin.Teams.AgentWatcher, name: Loomkin.Teams.AgentWatcher},
        Loomkin.Teams.RateLimiter,
        Loomkin.Teams.QueryRouter,
        {Task.Supervisor, name: Loomkin.Teams.TaskSupervisor}
      ] ++ cluster_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp cluster_children do
    if Loomkin.Teams.Cluster.enabled?() do
      [Loomkin.Teams.Cluster] ++ Loomkin.Teams.Distributed.child_specs()
    else
      []
    end
  end
end
