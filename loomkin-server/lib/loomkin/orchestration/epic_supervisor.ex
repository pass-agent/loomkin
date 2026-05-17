defmodule Loomkin.Orchestration.EpicSupervisor do
  @moduledoc """
  DynamicSupervisor for in-flight epics.

  One `Loomkin.Orchestration.IssueOrchestrator` child per active epic. Children
  are `:transient` so that successful closures terminate cleanly while crashes
  restart up to the gate-iteration cap.
  """
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start an `IssueOrchestrator` under this supervisor."
  def start_orchestrator(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Loomkin.Orchestration.IssueOrchestrator, opts})
  end

  @doc "List all active orchestrator children."
  def list_active do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
