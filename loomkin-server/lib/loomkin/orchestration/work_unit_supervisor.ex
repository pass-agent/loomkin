defmodule Loomkin.Orchestration.WorkUnitSupervisor do
  @moduledoc """
  DynamicSupervisor for `WorkUnitPipeline` processes.

  Started per-epic by `IssueOrchestrator`. Children are `:transient` so a
  successfully completed pipeline tears down cleanly while a crashed one
  restarts.
  """
  use DynamicSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Spawn a `WorkUnitPipeline` under this supervisor."
  def start_pipeline(sup, pipeline_opts) do
    DynamicSupervisor.start_child(sup, {Loomkin.Orchestration.WorkUnitPipeline, pipeline_opts})
  end
end
