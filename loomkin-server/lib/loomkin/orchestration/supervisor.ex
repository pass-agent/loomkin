defmodule Loomkin.Orchestration.Supervisor do
  @moduledoc """
  Supervision root for the orchestration subsystem.

  Started by `Loomkin.Application`. Children listed in the order they must
  start: registries before processes that register in them; review-gate
  task supervisor before any gate; knowledge store before the curator.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Loomkin.Orchestration.EpicRegistry},
      {Registry, keys: :unique, name: Loomkin.Orchestration.WorkUnitRegistry},
      {Registry, keys: :unique, name: Loomkin.Orchestration.ShepherdRegistry},
      {Task.Supervisor, name: Loomkin.Orchestration.ReviewGate.Supervisor},
      Loomkin.Orchestration.KnowledgeStore,
      Loomkin.Orchestration.EpicSupervisor,
      Loomkin.Orchestration.SwarmCoordinator,
      Loomkin.Orchestration.Curator,
      Loomkin.Orchestration.SignalBridge,
      Loomkin.Orchestration.Metrics.TelemetryHandler,
      Loomkin.Orchestration.CostTracker,
      Loomkin.Orchestration.PRShepherd.Supervisor,
      # Recovery MUST be last — it relies on EpicRegistry, EpicSupervisor,
      # and SwarmCoordinator all being already up when its handle_continue
      # sweep fires.
      Loomkin.Orchestration.Recovery
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
